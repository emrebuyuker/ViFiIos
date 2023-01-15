//
//  JPGTableViewCell.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit

class JPGTableViewCell: UITableViewCell {

    @IBOutlet weak var imegeView: UIImageView!
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
