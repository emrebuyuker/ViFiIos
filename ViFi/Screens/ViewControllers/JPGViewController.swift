//
//  JPGViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase

class JPGViewController: UIViewController {

    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonName = String()
    var examName = String()
    var examType = String()
    var imageURLArray = [String]()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = examName
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
        
        getDataFromFireBase()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        dataBaseRefence.child("Universities").child(uniName).child(facName).child(depName).child(lessonName).child(examName).child(examType).observe(DataEventType.childAdded) { (snapshot) in
            
            if (snapshot.key != "type") {
                
                let dataBaseRefence2 = Database.database().reference()
                dataBaseRefence2.child("Universities").child(self.uniName).child(self.facName).child(self.depName).child(self.lessonName).child(self.examName).child(self.examType).child(snapshot.key).observe(DataEventType.childAdded) { (snapshot) in
                    
                    if (snapshot.key != "type") {
                        if let value = snapshot.value as? String {
                            self.imageURLArray.append(value)
                        }
                    }
                }
            }
        }
    }
}
