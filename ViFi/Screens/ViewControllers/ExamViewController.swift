//
//  ExamViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase

class ExamViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonName = String()
    var examName = String()
    var examType = String()
    var examsNameArray = [String]()

    @IBOutlet weak var examTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        self.examTableView.delegate = self
        self.examTableView.dataSource = self
        
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
        
        tabBar.tabbarItem.isHidden = true
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        dataBaseRefence.child("Universities").child(uniName).child(facName).child(depName).child(lessonName).observe(DataEventType.childAdded) { (snapshot) in
            if (snapshot.key != "lessonname" ) {
                self.examsNameArray.append(snapshot.key)
            }
            self.examTableView.reloadData()
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.examsNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = examTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! ExamTableViewCell
        cell.examNameLabel.text = examsNameArray[indexPath.row]
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        examName = examsNameArray[indexPath.row]

        getDataFromFireBaseExamType()
    }
    
    func getDataFromFireBaseExamType() {
        let dataBaseRefence = Database.database().reference()
        dataBaseRefence.child("Universities").child(uniName).child(facName).child(depName).child(lessonName).child(examName).observe(DataEventType.childAdded) { (snapshot) in
            
            if (snapshot.key != "imagename" ) {
                self.examType = snapshot.key
            }
        }
        
        if (self.examType == "PDF") {
            performSegue(withIdentifier: "toPDFVC", sender: nil)
        }
        
        if (self.examType == "JPG") {
            performSegue(withIdentifier: "toJPGVC", sender: nil)
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "toJPGVC" {
            let destinationVC = segue.destination as! JPGViewController
            destinationVC.lessonName = self.lessonName
            destinationVC.examName = self.examName
            destinationVC.examType = self.examType
        }
        if segue.identifier == "toPDFVC" {
            let destinationVC = segue.destination as! PDFViewController
            destinationVC.lessonName = self.lessonName
            destinationVC.examName = self.examName
        }
    }
}
